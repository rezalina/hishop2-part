class ProductsController < InheritedResources::Base
  actions :index, :show
  skip_before_filter :authenticate_user!
  before_filter :session_utm, only: [:index, :show]
  belongs_to :sale
  belongs_to :category, optional: true

  def index
    @sale = Sale.find(params[:sale_id])

    if @sale.active?
      @all_products = @sale.products
      @products = if params[:category_id]
        category = Category.find(params[:category_id])

        begin
          category_id = category.id
          @sale.products.where("category_id = ?", category_id).page(params[:page]).per(21).reorder("product_name ASC")
        rescue
          []
        end
      else
        Kaminari.paginate_array(@sale.products.reorder("product_name ASC")).page(params[:page]).per(21)
      end
      expire_fragment("sale_products")
    else
      redirect_to sales_url
    end

  end

  def show
    @our_promise = AboutHishop.where(name: "Our Promises").first
    @product = Product.find(params[:id])
    if (@product.details_and_quantities and @product.details_and_quantities) and (@product.details_and_quantities.pluck(:available_balance).sum < 1)
      redirect_to sale_products_url(@sale)
    else
      ids = Photo.image_thumbnail.map(&:product_id)
      @product_suggests = Product.where("id IN (?)", ids).order("rand()").take(4)
    end
  end

  def load_dropdown_qty_options
    @dq = DetailsAndQuantity.find(params[:dq])
  end

  private

  def session_utm
    session[:utm_source] = params[:utm_source] if params[:utm_source]
    session[:utm_medium] = params[:utm_medium] if params[:utm_medium]
    session[:utm_campaign] = params[:utm_campaign] if params[:utm_campaign]
  end
end
